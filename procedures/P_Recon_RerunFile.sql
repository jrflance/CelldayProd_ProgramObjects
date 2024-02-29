--liquibase formatted sql

--changeset NicolasGriesdorn:dd2ba113 stripComments:false runOnChange:true
ALTER PROCEDURE [Tracfone].[P_Recon_RerunFile]
    (@FileID INT)
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    BEGIN TRY

        INSERT INTO CellDayTemp.Tracfone.tblReconReport
        (
            DateOrdered,
            OrderNo,
            SKU,
            OrderResponse,
            BillItemID,
            ORDER_DETAIL_TYPE,
            CARD_SMP,
            RTR_ESN,
            ORDER_DETAIL_STATUS,
            ESN_STATUS,
            PIN_STATUS,
            PIN_ESN,
            PhoneNumber,
            FileID
        )
        SELECT
            CAST(B.Chr1 AS DATETIME) AS [Chr1],
            CAST(B.Chr2 AS VARCHAR(100)) AS [Chr2],
            REPLACE(B.Chr3, '-', '') AS [Chr3],
            B.Chr4,
            B.Chr5,
            B.Chr6,
            B.Chr7,
            B.Chr8,
            B.Chr9,
            B.Chr10,
            B.Chr11,
            B.Chr12,
            REPLACE(REPLACE(B.Chr13, CHAR(13), ''), CHAR(10), '') AS [Chr13],
            @FileID AS [FileID]
        FROM CelldayTemp.Upload.tblPlainText AS p
        CROSS APPLY cellday_prod.dbo.SplitText(p.txt, ',', '"') AS B
        WHERE TRY_CAST(B.Chr1 AS DATETIME) IS NOT NULL AND p.fileid = @FileID

        ------ Update TCOrderNo
        UPDATE r
        SET r.TCOrderNo = od.Order_No
        FROM CellDayTemp.Tracfone.tblReconReport AS r
        JOIN CellDay_Prod.dbo.Order_No AS od
            ON r.OrderNo = od.Order_No
        WHERE
            r.Processed = 0 AND try_cast(r.OrderNo AS INT) IS NOT NULL
            AND r.FileID = @FileID;

        UPDATE r
        SET r.TCOrderNo = o.Order_No
        FROM CellDayTemp.Tracfone.tblReconReport AS r
        JOIN CellDay_Prod.dbo.tblOrderItemAddons AS oia ON r.OrderNo = oia.AddonsValue AND oia.AddonsID = 206
        JOIN CellDay_Prod.dbo.Orders AS o
            ON oia.OrderID = o.ID
        WHERE
            r.Processed = 0 AND try_cast(r.OrderNo AS INT) IS NULL AND TCOrderNo IS NULL
            AND r.FileID = @FileID;

        UPDATE r
        SET r.TCOrderNo = o.Order_No
        FROM CellDayTemp.Tracfone.tblReconReport AS r
        JOIN CellDay_Prod.dbo.tblOrderItemAddons AS oia ON r.BillItemID = oia.AddonsValue AND oia.AddonsID = 196
        JOIN CellDay_Prod.dbo.Orders AS o
            ON oia.OrderID = o.ID
        WHERE
            r.Processed = 0
            AND r.FileID = @FileID AND TCOrderNo IS NULL

        ------ Cannot location order
        UPDATE r
        SET r.Processed = 5
        FROM CellDayTemp.Tracfone.tblReconReport AS r
        WHERE
            r.Processed = 0
            AND r.FileID = @FileID
            AND TCOrderNo IS NULL

        ------ Not Billed order
        UPDATE r
        SET r.Processed = 4
        FROM CellDayTemp.Tracfone.tblReconReport AS r
        WHERE
            r.Processed = 0
            AND r.FileID = @FileID
            AND
            (
                r.ORDER_DETAIL_STATUS = 'FAILED'
                OR r.PIN_STATUS IN ('INVALID', 'NOT REDEEMED')
            );

        ------ filled order
        UPDATE r
        SET r.Processed = 1
        FROM CellDayTemp.Tracfone.tblReconReport AS r
        JOIN CellDay_Prod.dbo.Order_No AS od
            ON
                r.TCOrderNo = od.Order_No
                AND od.Filled = 1
                AND od.Process = 1
                AND od.Void = 0
        WHERE
            r.Processed = 0
            AND r.FileID = @FileID;

        ------ Void order
        UPDATE r
        SET r.Processed = 2
        FROM CellDayTemp.Tracfone.tblReconReport AS r
        JOIN CellDay_Prod.dbo.Order_No AS od
            ON
                r.TCOrderNo = od.Order_No
                AND od.Void = 1
        WHERE
            r.Processed = 0
            AND r.FileID = @FileID;

        ------ Pending order
        UPDATE r
        SET r.Processed = 3
        FROM CellDayTemp.Tracfone.tblReconReport AS r
        JOIN CellDay_Prod.dbo.Order_No AS od
            ON
                r.TCOrderNo = od.Order_No
                AND od.Filled = 0
                AND od.Void = 0
        WHERE
            r.Processed = 0
            AND r.FileID = @FileID;

    --SELECT r.DateOrdered,
    --       r.OrderNo,
    --       r.SKU,
    --       r.OrderResponse,
    --       r.BillItemID,
    --       r.ORDER_DETAIL_TYPE,
    --       r.CARD_SMP,
    --       r.RTR_ESN,
    --       r.ORDER_DETAIL_STATUS,
    --       r.ESN_STATUS,
    --       r.PIN_STATUS,
    --       r.PIN_ESN,
    --       r.PhoneNumber
    --FROM CellDayTemp.Tracfone.tblReconReport r
    --WHERE r.FileID = @FileID
    --      AND r.Processed = 2
    --UNION ALL
    --SELECT DISTINCT
    --    n.DateOrdered,
    --    n.Order_No,
    --    o.SKU,
    --    'Missing',
    --    '',
    --    CASE
    --        WHEN n.OrderType_ID IN ( 22, 23 ) THEN
    --            'ACTIVATION'
    --        ELSE
    --            'AIRTIME'
    --    END,
    --    '',
    --    '',
    --    CASE
    --        WHEN n.Filled = 1 THEN
    --            'Billed to dealer'
    --        ELSE
    --            'Not Billed to dealer'
    --    END,
    --    '',
    --    '',
    --    '',
    --    ISNULL(oia.AddonsValue, '')
    --FROM CellDay_Prod.dbo.Orders o
    --    JOIN CellDay_Prod.dbo.Order_No n
    --        ON n.Order_No = o.Order_No
    --    JOIN CellDay_Prod.dbo.Products p
    --        ON p.Product_ID = o.Product_ID
    --           AND p.Product_Type IN ( 1, 3 )
    --    JOIN CellDay_Prod.Products.tblProductCarrierMapping pcm
    --        ON o.Product_ID = pcm.ProductId
    --           AND pcm.CarrierId = 4
    --    LEFT JOIN CellDay_Prod.dbo.tblOrderItemAddons oia
    --        ON oia.OrderID = o.ID
    --           AND oia.AddonsID = 8
    --WHERE n.OrderType_ID IN ( 1, 9, 22, 23 )
    --      AND ISNULL(o.ParentItemID, 0) = 0
    --      AND LEN(o.SKU) > 16
    --      AND n.DateOrdered
    --      BETWEEN DATEADD(HOUR, -1, CAST(DATEADD(DAY, -1, CAST(GETDATE() AS DATE)) AS DATETIME)) AND DATEADD(
    --                                                                                                            HOUR,
    --                                                                                                            -1,
    --                                                                                                            CAST(CAST(GETDATE() AS DATE) AS DATETIME) -- noqa: LT05
    --                                                                                                        )
    --      AND n.Void = 0
    --      AND NOT EXISTS
    --(
    --    SELECT 1
    --    from CelldayTemp.Tracfone.tblReconReport r
    --    WHERE r.FileID = @FileID
    --          AND r.TCOrderNo = n.Order_No --TODO
    --)
    --      AND NOT EXISTS
    --(
    --    SELECT 1
    --    FROM CellDay_Prod.dbo.Order_Activation_User_Lock oaul
    --    WHERE oaul.Order_No = n.Order_No
    --);

    END TRY
    BEGIN CATCH
    ; THROW;
    END CATCH;
END
;
