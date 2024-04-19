--liquibase formatted sql

--changeset MoeDaaboul:cff97583-591d-4362-ab4e-d464584d978f stripComments:false runOnChange:true splitStatements:false

-- =============================================
--             :
--      Author : Rajagopal Vasudevan
--             :
-- Create Date : 04/18/2013
--             :
-- Description : Add to OrderItemAddons
--             :
--  JR20160516 : Swapped out @bypassflg conditional for "AND Activation_Type = 'byop'"
--             : for setting Status on failed activations.
--  JL20180807 : Optimized
--  MC20210601 : Added if statement to prevent reversing sim activation unless order is activation
--			   : Added Filter for initial activation order
-- =============================================
CREATE OR ALTER PROC [OrderManagment].[P_OrderManagment_FillActivationOrder]
    (
        @OrderNo INT,
        @isNotCompleted BIT,
        @ReasonID INT,
        @Reason VARCHAR(120),
        @Comment VARCHAR(250)
    )
AS
BEGIN TRY
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE
        @OrderTotal DECIMAL(9, 2),
        @AccountID INT,
        @SeriveOrderTotal DECIMAL(9, 2),
        @PromoOrderTotal DECIMAL(9, 2),
        @OrderTypeID INT;

    SELECT
        @OrderTotal = OrderTotal,
        @AccountID = Account_ID,
        @OrderTypeID = OrderType_ID
    FROM dbo.Order_No
    WHERE Order_No = @OrderNo;

    DECLARE
        @Orders TABLE
        (
            Order_no INT,
            Datedue DATETIME,
            IsDelayed BIT NULL
        );

    INSERT INTO @Orders
    (
        Order_no,
        Datedue
    )
    SELECT
        Order_No,
        dbo.fnCalculateDueDate(Account_ID, GETDATE()) AS Datedue
    FROM dbo.Order_No
    WHERE Order_No = @OrderNo;

    INSERT INTO @Orders
    (
        Order_no,
        Datedue
    )
    SELECT
        Order_No,
        DateDue
    FROM dbo.Order_No
    WHERE
        AuthNumber = CAST(@OrderNo AS NVARCHAR(50))
        AND OrderType_ID IN (50, 51);

    INSERT INTO @Orders
    (
        Order_no,
        Datedue,
        IsDelayed
    )
    SELECT
        promoOrder.Order_No,
        promoOrder.DateDue,
        CASE
            WHEN retroSpiffOrder.Order_No IS NULL THEN 0
            ELSE 1
        END AS IsDelayed
    FROM dbo.Order_No AS promoOrder
    LEFT JOIN
        dbo.Order_No AS retroSpiffOrder
        ON retroSpiffOrder.AuthNumber = CAST(@OrderNo AS NVARCHAR(50)) AND retroSpiffOrder.OrderType_ID IN (45, 46)
    WHERE
        promoOrder.AuthNumber = CAST(@OrderNo AS NVARCHAR(50))
        AND promoOrder.OrderType_ID IN (59, 60)
        AND promoOrder.Void <> 1

    UPDATE n
    SET
        Filled = CASE
            WHEN o.IsDelayed = 1 AND @isNotCompleted = 0 THEN 0
            ELSE 1
        END,
        Process = CASE
            WHEN o.IsDelayed = 1 AND @isNotCompleted = 0 THEN 0
            ELSE 1
        END,
        Comments = @Comment,
        Void = @isNotCompleted,
        DateFilled = GETDATE(),
        DateDue = o.Datedue
    FROM dbo.Order_No AS n
    JOIN @Orders AS o
        ON o.Order_no = n.Order_No;

    IF (@isNotCompleted = 1)
        BEGIN

            SELECT @SeriveOrderTotal = ISNULL(OrderTotal, 0)
            FROM dbo.Order_No
            WHERE
                AuthNumber = CAST(@OrderNo AS NVARCHAR(50))
                AND OrderType_ID IN (50, 51);

            DECLARE @PromoInfo TABLE (promoorder_no INT, PromoAmountTotal DECIMAL(9, 2))

            INSERT INTO @PromoInfo
            (
                promoorder_no,
                PromoAmountTotal
            )
            SELECT DISTINCT
                Order_No AS promoorder_no,
                ISNULL(OrderTotal, 0) AS PromoAmountTotal
            FROM dbo.Order_No
            WHERE
                AuthNumber = CAST(@OrderNo AS NVARCHAR(50))
                AND OrderType_ID IN (59, 60)
                AND Filled = 1;

            SELECT @PromoOrderTotal = SUM(ISNULL(PromoAmountTotal, 0))
            FROM @PromoInfo;

            IF (ISNULL(@SeriveOrderTotal, 0) + ISNULL(@OrderTotal, 0) + ISNULL(@PromoOrderTotal, 0) <> 0)
                BEGIN
                    UPDATE dbo.Account
                    SET
                        AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt + ISNULL(@SeriveOrderTotal, 0)
                        + ISNULL(@PromoOrderTotal, 0) + ISNULL(@OrderTotal, 0),
                        AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt + ISNULL(@SeriveOrderTotal, 0)
                        + ISNULL(@PromoOrderTotal, 0) + ISNULL(@OrderTotal, 0)
                    WHERE Account_ID = @AccountID;
                END;

            --UPDATE dbo.Order_No
            --SET Filled = 0,
            --    Process = 0,
            --    Void = 1
            --WHERE AuthNumber = CONVERT(NVARCHAR(50), @OrderNo)
            --      AND OrderType_ID IN ( 33, 34 );

            DELETE FROM dbo.tblOrderNOTCompletedReasonMap
            WHERE Order_No = @OrderNo;

            INSERT INTO dbo.tblOrderNOTCompletedReasonMap
            (
                Order_No,
                Reason,
                ReasonId
            )
            VALUES
            (@OrderNo, @Reason, @ReasonID);

            --MC20210601
            IF @OrderTypeID IN (22, 23)
                BEGIN

                    DECLARE @SimEsn TABLE (AddonsValue NVARCHAR(200))

                    INSERT INTO @SimEsn
                    (
                        AddonsValue
                    )
                    SELECT DISTINCT
                        ods.AddonsValue
                    FROM dbo.Orders AS o
                    JOIN dbo.tblOrderItemAddons AS ods
                        ON o.ID = ods.OrderID
                    JOIN dbo.tblAddonFamily AS af
                        ON
                            af.AddonID = ods.AddonsID
                            AND af.AddonTypeName IN ('simtype', 'simbyoptype', 'devicetype', 'devicebyoptype')
                    WHERE o.Order_No IN (
                        SELECT @OrderNo AS OrdNO
                        UNION
                        SELECT promoorder_no AS OrdNO
                        FROM @PromoInfo
                    )
                    AND o.ParentItemID = 0;

                    UPDATE pak
                    SET
                        Active_Status = 0,
                        Status = CASE WHEN Activation_Type = 'byop' THEN 0 ELSE Status END,
                        Area_Code = NULL
                    FROM dbo.Phone_Active_Kit AS pak
                    JOIN @SimEsn AS se ON pak.Sim_ID = se.AddonsValue
                    WHERE @OrderNo = TRIM(ISNULL(AREA_CODE, '0')); --MC20210601
                END;
        END;

END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
