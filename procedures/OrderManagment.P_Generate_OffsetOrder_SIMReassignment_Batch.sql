--liquibase formatted sql

--changeset Brandon Stahl/Business Solutions:8533cbb3-16cd-43d1-be58-f2e4db601152 stripComments:false runOnChange:true splitStatements:false

-- =============================================
--             :
--      Author : Brandon Stahl
--             :
--     Created : 10/23/2023
--             :
--IMPACTED DATABASE NAME: CellDay_Prod
--IMPACTED SCHEMA NAME(S): dbo.
--IMPACTED TABLE NAME(S): dbo.Order_No, dbo.Orders,
--             :
--PURPOSE
--    Generate offset orders when reassignment orders move branded devices out from merchant inventory.
--			   : Based off [OrderManagment].[P_Generate_OffsetOrder_SIMReassignment]
-- =============================================
CREATE OR ALTER PROCEDURE [OrderManagment].[P_Generate_OffsetOrder_SIMReassignment_Batch]
    (
        @OrderNumbers dbo.IDS READONLY
    )
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE @RtnCode INT = 0;
    BEGIN TRY
        IF OBJECT_ID('tempdb..#Unfulfilled') IS NOT NULL
            BEGIN
                DROP TABLE #Unfulfilled;
            END;
        SELECT
            n.Order_No AS AssignmentOrderNO,
            n.Account_ID AS NewAccountID,
            o.Dropship_Account_ID AS OldAccountID,
            o.ID AS assignmentOrderID,
            o.SKU AS reassignedSKU,
            o.Product_ID,
            pak.PONumber
        INTO #Unfulfilled
        FROM dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN @OrderNumbers AS os
            ON os.ID = n.Order_No
        JOIN dbo.Phone_Active_Kit AS pak
            ON
                o.SKU = pak.Sim_ID
                AND pak.Activation_Type IN ('Branded', 'TCBranded')
                AND pak.Status = 1;

        ----- Remove record without PO
        DELETE uf
        FROM #Unfulfilled AS uf
        WHERE
            NOT EXISTS
            (
                SELECT 1
                FROM dbo.Order_No
                WHERE
                    Order_No.Order_No = uf.PONumber
                    AND Order_No.OrderType_ID IN (57, 58)
            );
        SET @RtnCode = @@rowcount

        ----- Remove already processed
        ;
        WITH XCLV AS (
            SELECT DISTINCT
                u.assignmentOrderID
            FROM dbo.Order_No AS n
            JOIN dbo.Orders AS o
                ON n.Order_No = o.Order_No
            JOIN #Unfulfilled AS u
                ON
                    CAST(u.assignmentOrderID AS NVARCHAR(20)) = o.SKU
                    AND n.AuthNumber = CAST(u.AssignmentOrderNO AS BIGINT)
            WHERE n.OrderType_ID IN (65, 66)
        )
        DELETE u
        FROM #Unfulfilled AS u
        WHERE
            u.assignmentOrderID IN
            (
                SELECT XCLV.assignmentOrderID FROM XCLV
            );
        IF
            (
                SELECT COUNT(1) FROM #Unfulfilled
            ) = 0
            BEGIN
                RETURN @RtnCode;
            END;

        ------------------------------------- Generating Offset Order info --------------------------------
        DECLARE @TranCounter INT = @@TRANCOUNT;

        IF @TranCounter > 0
            SAVE TRANSACTION SaveCallerTrans;
        ELSE
            BEGIN TRANSACTION;

        CREATE CLUSTERED INDEX idx_NC_TEMP_Unfulfilled
            ON #Unfulfilled (AssignmentOrderNO);
        DECLARE @ToCreate ORDERFULLDETAILTBLWFLG;
        INSERT INTO @ToCreate
        (
            Account_ID,
            CustomerID,
            SHIPTO,
            USERID,
            OrderType_Id,
            RefOrderNo,
            DateDue,
            CreditTermID,
            DiscountClassID,
            DateFrom,
            DateFilled,
            OrderTotal,
            Process,
            Filled,
            Void,
            Product_ID,
            ProductName,
            SKU,
            PRICE,
            DiscAmount,
            FEE,
            Tracking,
            User_IPAddress,
            Comments,
            IsUnique
        )
        SELECT
            uf.OldAccountID,
            ac.Customer_ID,
            ac.ShipTo,
            ac.User_ID,
            IIF(ac.AccountType_ID = 11, 66, 65) AS Ordertype_ID,
            CAST(uf.AssignmentOrderNO AS VARCHAR(20)) + CAST(uf.OldAccountID AS VARCHAR(10)) AS AccountId,
            dbo.fnCalculateDueDate(uf.OldAccountID, GETDATE()) AS DateDue,
            ac.CreditTerms_ID,
            ac.DiscountClass_ID,
            GETDATE() AS DateFrom,
            GETDATE() AS DateFilled,
            (-1.0) * SUM(od.Price - od.DiscAmount) OVER (PARTITION BY od.Id) AS OrderTotal,
            1 AS process,
            1 AS filled,
            0 AS void,
            uf.Product_ID,
            od.Name,
            CAST(uf.assignmentOrderID AS NVARCHAR(100)) AS SKU,
            (-1.0) * od.Price AS price,
            (-1.0) * od.DiscAmount AS DiscAmount,
            0 AS Fee,
            '127.0.0.1' AS Tracking,
            '192.168.151.9' AS User_IPAddress,
            '' AS Comments,
            0 AS IsUnique
        FROM #Unfulfilled AS uf
        JOIN dbo.Orders AS od
            ON
                uf.PONumber = od.Order_No
                AND
                (
                    EXISTS
                    (
                        SELECT 1
                        FROM dbo.tblOrderItemAddons AS oia
                        WHERE
                            oia.OrderID = od.ID
                            AND oia.AddonsValue = uf.reassignedSKU
                    )
                    OR od.SKU = uf.reassignedSKU
                )
        JOIN dbo.Account AS ac
            ON uf.OldAccountID = ac.Account_ID;
        CREATE TABLE #rtn
        (
            orderID INT,
            orderno INT
        );

        INSERT INTO #rtn
        (
            orderID,
            orderno
        )

        EXEC OrderManagment.P_OrderManagment_Build_Full_Order_table_wTracking_IP_inBatch @OrderDetail = @ToCreate;

        UPDATE o
        SET o.AuthNumber = REPLACE(o.AuthNumber, CAST(o.Account_ID AS VARCHAR(10)), '')
        FROM dbo.Order_No AS o
        JOIN #rtn AS r
            ON o.Order_No = r.orderno;

        IF @TranCounter = 0
            COMMIT;
        RETURN @RtnCode;
    END TRY
    BEGIN CATCH
        IF @TranCounter = 0
            ROLLBACK;
        ELSE
        IF XACT_STATE() <> -1
            ROLLBACK TRANSACTION SaveCallerTrans;
        THROW;
    END CATCH;
END;
